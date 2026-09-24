class TasksController < ApplicationController
  before_action :set_project, only: %i[index create]
  before_action :set_task, only: %i[show update destroy complete]

  def index
    tasks = @project.tasks.order(:due_on, :id)
    tasks = tasks.where(status: params[:status]) if params[:status].present?
    tasks = tasks.search(params[:q]) if params[:q].present?
    render json: tasks.map { |task| task.as_json.merge("overdue" => task.overdue?) }
  end

  def show
    render json: @task
  end

  def create
    task = @project.tasks.create!(task_params)
    render json: task, status: :created
  end

  def update
    @task.update!(task_params)
    render json: @task
  end

  def destroy
    @task.destroy!
    head :no_content
  end

  def complete
    @task.done!
    render json: @task
  end

  private

  def set_project
    @project = current_user.projects.find(params[:project_id])
  end

  def set_task
    @task = Task.joins(project: :memberships).where(memberships: { user_id: current_user.id }).find(params[:id])
  end

  def task_params
    params.expect(task: %i[title notes status priority estimate due_on assignee_id])
  end
end
